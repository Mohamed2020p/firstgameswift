# -*- coding: utf-8 -*-
"""
Uploads ONLY the files that are new or different to your existing GitHub repository, as ONE normal commit (no force push, no git needed).

    python tools/upload_changes.py --dry-run     # lists what would be uploaded, changes nothing
    python tools/upload_changes.py               # uploads the new / changed files

How it works: it asks GitHub for the file list of the branch (with each file's fingerprint), computes the same fingerprint for every local file
and uploads only the files that are missing or different.  Files that exist on GitHub but not locally are left alone (they are only listed).

Token: a GitHub classic personal access token with the "repo" scope.  It is read from the GITHUB_TOKEN environment variable or typed in
(hidden).  It is only sent to api.github.com, never written to disk and never printed.
"""
import argparse
import base64
import getpass
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

DEFAULT_REPO = "https://github.com/Mohamed2020p/firstgameswift.git"
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {".git", "__pycache__", "assets_src", "DerivedData", "build", ".idea", ".vscode"}
SKIP_FILES = {".DS_Store", "Thumbs.db"}
SKIP_EXT = {".pyc", ".tmp"}
TEXT_EXT = {".swift", ".py", ".md", ".txt", ".json", ".yaml", ".yml", ".pbxproj", ".plist", ".xcscheme", ".xcworkspacedata", ".strings", ".gitignore", ".sh"}
MAX_FILE = 95 * 1024 * 1024


def fail(msg):
    print("\nERROR: " + msg)
    sys.exit(1)


class Api(object):
    def __init__(self, owner, repo, token):
        self.base = "https://api.github.com/repos/%s/%s" % (owner, repo)
        self.token = token

    def call(self, method, path, body=None, tries=4):
        url = self.base + path
        data = json.dumps(body).encode("utf-8") if body is not None else None
        for attempt in range(tries):
            req = urllib.request.Request(url, data=data, method=method)
            req.add_header("Authorization", "Bearer " + self.token)
            req.add_header("Accept", "application/vnd.github+json")
            req.add_header("User-Agent", "supercars-uploader")
            if data is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=180) as r:
                    return json.loads(r.read().decode("utf-8") or "{}")
            except urllib.error.HTTPError as e:
                text = e.read().decode("utf-8", "replace")
                if e.code in (401, 403) and "rate limit" not in text.lower():
                    fail("GitHub refused the token (HTTP %d). Use a classic token with the 'repo' scope that belongs to the repo owner "
                         "(or a collaborator)." % e.code)
                if e.code == 404:
                    fail("not found (HTTP 404) for %s. Check the repo URL / branch name, and that the token can see private repos." % path)
                if e.code >= 500 or e.code == 429 or "rate limit" in text.lower():
                    time.sleep(2 + attempt * 3)
                    continue
                fail("GitHub error HTTP %d on %s: %s" % (e.code, path, text[:300]))
            except (urllib.error.URLError, OSError):
                time.sleep(2 + attempt * 3)
        fail("network problem talking to GitHub (%s). Try again." % path)


def git_blob_sha(data):
    h = hashlib.sha1()
    h.update(("blob %d\0" % len(data)).encode("ascii"))
    h.update(data)
    return h.hexdigest()


def local_files():
    out = {}
    for dp, dn, fn in os.walk(PROJECT_ROOT):
        dn[:] = [d for d in dn if d not in SKIP_DIRS]
        for f in fn:
            if f in SKIP_FILES or os.path.splitext(f)[1].lower() in SKIP_EXT:
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, PROJECT_ROOT).replace("\\", "/")
            out[rel] = p
    return out


def human(n):
    return "%.1f MB" % (n / 1048576.0) if n >= 1048576 else "%.0f KB" % (n / 1024.0)


def main():
    ap = argparse.ArgumentParser(description="Upload only new / changed files to GitHub")
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--branch", default="main")
    ap.add_argument("--message", default="Supercars: living city, NPCs, taxi / police / wanted, map + navigation, endless world, Porsche suspension, house rework")
    ap.add_argument("--dry-run", action="store_true", help="only list what would be uploaded")
    ap.add_argument("--delete-removed", action="store_true",
                    help="also delete files under Supercars/ that exist on GitHub but no longer exist locally (only needed if a Swift file was removed)")
    args = ap.parse_args()

    url = args.repo
    if url.endswith(".git"):
        url = url[:-4]
    parts = url.rstrip("/").split("/")
    if len(parts) < 2 or "github.com" not in url:
        fail("use a https://github.com/OWNER/REPO URL")
    owner, repo = parts[-2], parts[-1]
    print("SUPERCARS -> GitHub (changed files only)")
    print("  repo   : %s/%s   branch: %s" % (owner, repo, args.branch))
    print("  folder : " + PROJECT_ROOT)

    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        print("\nPaste your GitHub token (scope: repo). Nothing is shown while you type/paste.")
        token = getpass.getpass("token: ").strip()
    if not token:
        fail("no token given.")
    api = Api(owner, repo, token)

    print("\n[1/5] reading the repository")
    ref = api.call("GET", "/git/ref/heads/" + args.branch)
    head_sha = ref["object"]["sha"]
    head = api.call("GET", "/git/commits/" + head_sha)
    base_tree = head["tree"]["sha"]
    tree = api.call("GET", "/git/trees/%s?recursive=1" % base_tree)
    if tree.get("truncated"):
        fail("the repository is too large for a single tree listing.")
    remote = {t["path"]: t["sha"] for t in tree["tree"] if t["type"] == "blob"}
    print("      %d files on GitHub" % len(remote))

    print("[2/5] comparing with your local files")
    local = local_files()
    changed, new, same = [], [], 0
    for rel in sorted(local):
        path = local[rel]
        size = os.path.getsize(path)
        if size > MAX_FILE:
            fail("%s is %s; GitHub rejects files above 100 MB." % (rel, human(size)))
        data = open(path, "rb").read()
        sha = git_blob_sha(data)
        old = remote.get(rel)
        if old == sha:
            same += 1
            continue
        if old is not None and os.path.splitext(rel)[1].lower() in TEXT_EXT and b"\r\n" in data:
            if git_blob_sha(data.replace(b"\r\n", b"\n")) == old:      # only the line endings differ
                same += 1
                continue
        (changed if old is not None else new).append((rel, path, size))
    removed = sorted(p for p in remote if p not in local and p.startswith("Supercars/"))

    print("      unchanged: %d   changed: %d   new: %d" % (same, len(changed), len(new)))
    for label, items in (("CHANGED", changed), ("NEW", new)):
        for rel, _, size in items:
            print("      %-8s %s  (%s)" % (label, rel, human(size)))
    if removed:
        print("      on GitHub but not local (%d), %s:" % (len(removed), "will be DELETED" if args.delete_removed else "left alone"))
        for p in removed:
            print("         " + p)
        if not args.delete_removed:
            print("      (if any of these is an old Swift file you no longer use, run again with --delete-removed)")

    todo = changed + new
    if not todo and not (removed and args.delete_removed):
        print("\nNothing to upload: GitHub already has everything.")
        return 0
    total = sum(s for _, _, s in todo)
    print("\n      %d files, %s to upload" % (len(todo), human(total)))
    if args.dry_run:
        print("\nDRY RUN: nothing was uploaded.")
        return 0

    print("[3/5] uploading files")
    entries = []
    done = 0
    for rel, path, size in todo:
        data = open(path, "rb").read()
        blob = api.call("POST", "/git/blobs", {"content": base64.b64encode(data).decode("ascii"), "encoding": "base64"})
        mode = "100755" if rel.endswith(".sh") else "100644"
        entries.append({"path": rel, "mode": mode, "type": "blob", "sha": blob["sha"]})
        done += 1
        print("      %3d/%d  %s" % (done, len(todo), rel))
    if args.delete_removed:
        for p in removed:
            entries.append({"path": p, "mode": "100644", "type": "blob", "sha": None})

    print("[4/5] creating the commit")
    new_tree = api.call("POST", "/git/trees", {"base_tree": base_tree, "tree": entries})
    commit = api.call("POST", "/git/commits", {"message": args.message, "tree": new_tree["sha"], "parents": [head_sha]})

    print("[5/5] moving the branch")
    api.call("PATCH", "/git/refs/heads/" + args.branch, {"sha": commit["sha"], "force": False})
    print("\nDone: commit %s pushed to %s/%s (%s)." % (commit["sha"][:7], owner, repo, args.branch))
    print("Next: run the build_ipa workflow on Bitrise (or it starts by itself if a trigger is set).")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\ncancelled.")
        sys.exit(130)
