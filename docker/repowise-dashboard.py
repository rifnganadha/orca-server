#!/opt/repowise/bin/python3

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from repowise.core.workspace.config import RepoEntry, WorkspaceConfig


PROJECTS_ROOT = Path("/home/orca/orca/projects")
SCAN_INTERVAL_SECONDS = 10
dashboard: subprocess.Popen[str] | None = None
stopping = False


def discover_repositories() -> list[Path]:
    repositories = {
        marker.parent.resolve()
        for marker in PROJECTS_ROOT.rglob(".git")
        if marker.is_dir() or marker.is_file()
    }
    return sorted(repositories)


def unique_alias(repository: Path, used: set[str]) -> str:
    base = repository.name
    alias = base
    suffix = 2
    while alias in used:
        alias = f"{base}-{suffix}"
        suffix += 1
    return alias


def ensure_index(repository: Path) -> None:
    repowise_dir = repository / ".repowise"
    if (repowise_dir / "wiki.db").is_file() and (repowise_dir / "state.json").is_file():
        return

    print(f"Indexing newly discovered repository: {repository}", flush=True)
    subprocess.run(
        [
            "repowise",
            "init",
            "--yes",
            "--no-prose",
            "--no-editor-setup",
        ],
        cwd=repository,
        check=True,
        env={
            **os.environ,
            "REPOWISE_EMBEDDER": "mock",
            "REPOWISE_SKIP_EDITOR_SETUP": "1",
        },
    )


def write_workspace(repositories: list[Path]) -> None:
    config_path = PROJECTS_ROOT / ".repowise-workspace.yaml"
    previous_aliases: dict[str, str] = {}
    if config_path.is_file():
        previous = WorkspaceConfig.load(PROJECTS_ROOT)
        previous_aliases = {entry.path: entry.alias for entry in previous.repos}

    entries: list[RepoEntry] = []
    used_aliases: set[str] = set()
    for repository in repositories:
        relative_path = repository.relative_to(PROJECTS_ROOT).as_posix()
        alias = previous_aliases.get(relative_path)
        if not alias or alias in used_aliases:
            alias = unique_alias(repository, used_aliases)
        used_aliases.add(alias)
        entries.append(
            RepoEntry(
                path=relative_path,
                alias=alias,
                is_primary=not entries,
            )
        )

    default_repo = entries[0].alias if entries else None
    WorkspaceConfig(version=1, repos=entries, default_repo=default_repo).save(PROJECTS_ROOT)


def stop_dashboard() -> None:
    global dashboard
    if dashboard is not None and dashboard.poll() is None:
        os.killpg(dashboard.pid, signal.SIGTERM)
        try:
            dashboard.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(dashboard.pid, signal.SIGKILL)
            dashboard.wait()
    dashboard = None


def patch_sidebar_bundle() -> None:
    bundle = Path.home() / ".repowise" / "web" / ".next" / "static" / "chunks" / "app"
    source = 'let{repos:l=[],activeRepoId:x,workspace:N}=e,A='
    replacement = (
        'let{repos:q=[],activeRepoId:x,workspace:N}=e,[l,H]=o.useState(q);'
        'o.useEffect(()=>{0===q.length&&fetch("/api/repos").then(e=>e.ok?e.json():[])'
        '.then(H).catch(()=>{})},[q.length]);let A='
    )

    for candidate in bundle.glob("layout-*.js"):
        content = candidate.read_text(encoding="utf-8")
        if replacement in content:
            return
        if source in content:
            candidate.write_text(content.replace(source, replacement, 1), encoding="utf-8")
            print("Patched RepoWise sidebar to load repositories on static pages.", flush=True)
            return

    raise RuntimeError("Could not locate the RepoWise sidebar bundle.")


def start_dashboard() -> None:
    global dashboard
    dashboard = subprocess.Popen(
        [
            "repowise",
            "serve",
            "--host",
            "127.0.0.1",
            "--port",
            "7337",
            "--ui-port",
            "7340",
        ],
        cwd=PROJECTS_ROOT,
        env={
            **os.environ,
            "REPOWISE_EMBEDDER": "mock",
            "REPOWISE_TELEMETRY_DISABLED": "1",
        },
        start_new_session=True,
        text=True,
    )
    for _ in range(120):
        if list((Path.home() / ".repowise" / "web" / ".next" / "static" / "chunks" / "app").glob("layout-*.js")):
            patch_sidebar_bundle()
            return
        if dashboard.poll() is not None:
            raise RuntimeError("RepoWise dashboard exited during startup.")
        time.sleep(0.5)
    raise RuntimeError("RepoWise web bundle was not available within 60 seconds.")


def handle_signal(_signum: int, _frame: object) -> None:
    global stopping
    stopping = True
    stop_dashboard()


def main() -> int:
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    PROJECTS_ROOT.mkdir(parents=True, exist_ok=True)
    previous_membership: tuple[str, ...] | None = None

    while not stopping:
        repositories = discover_repositories()
        membership = tuple(str(repository) for repository in repositories)

        if membership != previous_membership:
            stop_dashboard()
            for repository in repositories:
                ensure_index(repository)
            write_workspace(repositories)
            start_dashboard()
            previous_membership = membership
            print(f"RepoWise dashboard registered {len(repositories)} repositories.", flush=True)
        elif dashboard is not None and dashboard.poll() is not None:
            print("RepoWise dashboard stopped unexpectedly; restarting.", file=sys.stderr, flush=True)
            start_dashboard()

        time.sleep(SCAN_INTERVAL_SECONDS)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
