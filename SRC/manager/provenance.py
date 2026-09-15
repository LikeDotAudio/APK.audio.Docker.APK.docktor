# Part of the APK.audio project — http://APK.audio — made by Anthony Kuzub
# MIT Licence. Full text in LICENSE at the root.
"""🐙 Where a container comes from, as links a person can open.

OWNS the step from a path on disk to the GitHub page for it. The detail pane
said which compose file built a container and nothing about where that file,
or anything it pulls in, is kept.
ONE LINK PER FILE, IN THE REPOSITORY THAT OWNS IT — not one repository per
container. Every stack under APK:PODS/ is its own submodule with its own
remote, and a Dockerfile in one routinely COPYs out of another: Storage-Portal
serves trees owned by WebPortal, BareMetal, Docktor and the root repository.
Calling all of that "the SQL repo" would send a reader to the wrong home for
most of what built it.
READS .git FILES AND RUNS NO git: the manager image carries no git binary, and
the checkout is bind-mounted at its host path, so the same files answer inside
the container and at a terminal.
WHAT IS TRACED comes from staleness.sh, which already walks each build's
Dockerfile stage graph to find the COPY sources that enter the image. A second
Dockerfile parser here would drift from the one deciding staleness.
"""

import os
import re
from urllib.parse import quote

from .paths import REPOSITORY_ROOT
from .readers import read_build_services

_FROM = re.compile(r'^\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?', re.I)
_SCP_REMOTE = re.compile(r'^(?:ssh://)?git@([^:/]+)[:/](.+)$')
_GLOB = set("*?[")


def github_web_url(remote):
    """`git@github.com:Org/Repo.git` or `https://…/Repo.git` -> `https://github.com/Org/Repo`.

    '' for anything that is not a web-reachable remote (a local path, a bundle).
    Credentials in an https remote are dropped rather than handed to a browser.
    """
    url = (remote or "").strip()
    match = _SCP_REMOTE.match(url)
    if match:
        url = f"https://{match.group(1)}/{match.group(2)}"
    url = re.sub(r'^(https?://)[^@/]+@', r'\1', url)
    if url.endswith(".git"):
        url = url[:-4]
    return url.rstrip("/") if url.startswith(("https://", "http://")) else ""


def _gitdir(top):
    """The git directory for a worktree root: `.git` itself, or where a submodule's `.git` file points."""
    dotgit = os.path.join(top, ".git")
    if os.path.isdir(dotgit):
        return dotgit
    try:
        with open(dotgit, encoding="utf-8", errors="replace") as handle:
            first = handle.readline().strip()
    except OSError:
        return None
    if not first.startswith("gitdir:"):
        return None
    return os.path.normpath(os.path.join(top, first[len("gitdir:"):].strip()))


def _origin(gitdir):
    """remote.origin.url, read out of the config file."""
    try:
        with open(os.path.join(gitdir, "config"), encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return ""
    in_origin = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            in_origin = stripped == '[remote "origin"]'
        elif in_origin and stripped.split("=", 1)[0].strip() == "url":
            return stripped.split("=", 1)[1].strip()
    return ""


def _branch(gitdir):
    """The checked-out branch, or the commit when HEAD is detached."""
    try:
        with open(os.path.join(gitdir, "HEAD"), encoding="utf-8", errors="replace") as handle:
            head = handle.read().strip()
    except OSError:
        return ""
    if head.startswith("ref: refs/heads/"):
        return head[len("ref: refs/heads/"):]
    return head[:40]


def repository_of(path, cache):
    """{top, name, url, branch} for the innermost git worktree holding `path`, or None.

    INNERMOST, so a file in a submodule belongs to the submodule and not to the
    superproject that also contains it on disk. `cache` is per call: a branch
    switched between two clicks must show on the second.
    """
    here = os.path.realpath(path)
    if not os.path.isdir(here):
        here = os.path.dirname(here)
    while not os.path.exists(os.path.join(here, ".git")):
        parent = os.path.dirname(here)
        if parent == here:
            return None
        here = parent
    if here not in cache:
        gitdir = _gitdir(here)
        cache[here] = {
            "top": here,
            "name": os.path.basename(here) or here,
            "url": github_web_url(_origin(gitdir)) if gitdir else "",
            "branch": _branch(gitdir) if gitdir else "",
        }
    return cache[here]


def _shown(path):
    """Repository-relative when the path is inside this checkout, as the rest of the pane prints them."""
    root = os.path.realpath(REPOSITORY_ROOT)
    normal = os.path.normpath(path)
    if normal == root or normal.startswith(root + os.sep):
        return os.path.relpath(normal, root)
    return normal


def file_link(path, role, cache):
    """One row: what the file is to this container, where it is, and its page on GitHub.

    A GLOB SOURCE (`COPY scripts/*.sh`) links its directory: GitHub has no page
    for a pattern. The URL names the checked-out branch, so an uncommitted or
    unpushed file links to a page that 404s — the path beside it stays true.
    """
    probe = os.path.dirname(path) if _GLOB & set(path) else path
    real = os.path.realpath(probe)
    exists = os.path.exists(real)
    repo = repository_of(real, cache) if exists else None
    url = ""
    if repo and repo["url"]:
        relative = os.path.relpath(real, repo["top"])
        if relative == ".":
            url = repo["url"]
        else:
            kind = "tree" if os.path.isdir(real) else "blob"
            url = f'{repo["url"]}/{kind}/{quote(repo["branch"] or "HEAD")}/{quote(relative, safe="/:")}'
    return {"role": role, "path": _shown(path), "url": url, "exists": exists,
            "repository": repo["name"] if repo else "",
            "repository_url": repo["url"] if repo else ""}


def image_link(image):
    """{path, url} for an image reference: its Docker Hub page, or no URL for another registry."""
    reference = image.split("@", 1)[0]
    slash, colon = reference.rfind("/"), reference.rfind(":")
    name = reference[:colon] if colon > slash else reference
    parts = name.split("/")
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        if parts[0] not in ("docker.io", "index.docker.io", "registry-1.docker.io"):
            return {"path": image, "url": ""}
        parts = parts[1:]
    if parts and parts[0] == "library":
        parts = parts[1:]
    if len(parts) == 1:
        url = f"https://hub.docker.com/_/{parts[0]}"
    else:
        url = f"https://hub.docker.com/r/{'/'.join(parts[:2])}"
    return {"path": image, "url": url}


def base_images(dockerfile):
    """Every external image a Dockerfile builds FROM, in order, without the stages it names itself."""
    try:
        with open(dockerfile, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return []
    stages, images = set(), []
    for line in text.splitlines():
        match = _FROM.match(line)
        if not match:
            continue
        reference = match.group(1)
        if reference.lower() not in stages and reference != "scratch" and "$" not in reference:
            images.append(reference)
        if match.group(2):
            stages.add(match.group(2).lower())
    return images


def container_provenance(name, config_path="", image="", quiet=True):
    """The repository a container is declared in, and a link for everything that makes it.

    Returns {repository, made_by, images, repositories, built_here}:
      repository    {name, url, branch} owning the compose file, or None
      made_by       [{role, path, url, repository, repository_url, exists}] —
                    compose file, Dockerfile, .dockerignore, every COPY source
      images        [{path, url}] — FROM images when built here, else the pulled image
      repositories  [{name, url}] every repository made_by reaches, once each
      built_here    False for a container run from a pulled image, which has no
                    Dockerfile in this checkout to trace
    """
    cache = {}
    services = [s for s in read_build_services(quiet=quiet) if s.get("container") == name]
    made_by, seen = [], set()

    def add(path, role):
        key = os.path.normpath(path)
        if key in seen:
            return
        seen.add(key)
        made_by.append(file_link(path, role, cache))

    if config_path and not os.path.isabs(config_path):
        config_path = os.path.join(REPOSITORY_ROOT, config_path)
    compose = services[0]["compose_file"] if services else config_path
    if compose:
        add(compose, "Compose file")

    images = []
    for service in services:
        target = service.get("target")
        add(service["dockerfile"], f"Dockerfile ({target})" if target else "Dockerfile")
        ignore = os.path.join(service["context"], ".dockerignore")
        if os.path.isfile(ignore):
            add(ignore, ".dockerignore")
        for source in service.get("sources") or []:
            add(os.path.join(service["context"], source), "COPY source")
        images += base_images(service["dockerfile"])
    if not services and image:
        images.append(image)

    home = repository_of(compose, cache) if compose and os.path.exists(compose) else None
    reached = {}
    for row in made_by:
        if row["repository"]:
            reached.setdefault(row["repository"], row["repository_url"])
    return {
        "repository": ({"name": home["name"], "url": home["url"], "branch": home["branch"]}
                       if home else None),
        "made_by": made_by,
        "images": [image_link(reference) for reference in dict.fromkeys(images)],
        "repositories": [{"name": key, "url": value} for key, value in sorted(reached.items())],
        "built_here": bool(services),
    }
