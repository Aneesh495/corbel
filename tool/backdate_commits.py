import os
import random
import subprocess
from datetime import datetime, timedelta
import zoneinfo

def generate_timestamps(num_commits: int):
    eastern = zoneinfo.ZoneInfo("America/New_York")
    start_dt = datetime(2023, 1, 18, 14, 25, 12, tzinfo=eastern)
    end_dt = datetime(2023, 6, 25, 20, 45, 33, tzinfo=eastern)

    total_sec = (end_dt - start_dt).total_seconds()
    random.seed(42)

    weights = []
    for _ in range(num_commits - 1):
        r = random.random()
        if r < 0.25:
            # Same day burst: 1-5 hours
            w = random.uniform(0.04, 0.20)
        elif r < 0.80:
            # Standard 1-2 day gap
            w = random.uniform(0.7, 1.5)
        else:
            # 3-4 day sprint gap
            w = random.uniform(1.8, 3.2)
        weights.append(w)

    scale = total_sec / sum(weights)
    gaps = [w * scale for w in weights]

    cur = start_dt
    dts = [cur]
    for g in gaps:
        cur = cur + timedelta(seconds=g)
        local_h = cur.hour
        if 1 <= local_h <= 8:
            nudge_h = random.randint(10, 14)
            cur = cur.replace(hour=nudge_h, minute=random.randint(0, 59))
            if cur <= dts[-1]:
                cur = dts[-1] + timedelta(minutes=random.randint(45, 180))
        dts.append(cur)

    # Ensure strictly monotonic
    for i in range(1, len(dts)):
        if dts[i] <= dts[i - 1]:
            dts[i] = dts[i - 1] + timedelta(minutes=random.randint(30, 120))

    return dts

def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(repo_dir)

    raw_commits = subprocess.check_output(
        ["git", "rev-list", "--reverse", "main"]
    ).decode().strip().split("\n")

    num_commits = len(raw_commits)
    print(f"Total commits to rewrite: {num_commits}")

    timestamps = generate_timestamps(num_commits)

    prev_commit = None
    new_commits = []

    for i, (old_hash, dt) in enumerate(zip(raw_commits, timestamps)):
        tree = subprocess.check_output(
            ["git", "rev-parse", f"{old_hash}^{{tree}}"]
        ).decode().strip()

        msg = subprocess.check_output(
            ["git", "log", "-1", "--format=%B", old_hash]
        ).decode()

        author_name = subprocess.check_output(
            ["git", "log", "-1", "--format=%an", old_hash]
        ).decode().strip()

        author_email = subprocess.check_output(
            ["git", "log", "-1", "--format=%ae", old_hash]
        ).decode().strip()

        date_str = dt.strftime("%Y-%m-%d %H:%M:%S %z")

        env = os.environ.copy()
        env["GIT_AUTHOR_NAME"] = author_name
        env["GIT_AUTHOR_EMAIL"] = author_email
        env["GIT_AUTHOR_DATE"] = date_str
        env["GIT_COMMITTER_NAME"] = author_name
        env["GIT_COMMITTER_EMAIL"] = author_email
        env["GIT_COMMITTER_DATE"] = date_str

        cmd = ["git", "commit-tree", tree]
        if prev_commit:
            cmd.extend(["-p", prev_commit])
        cmd.extend(["-m", msg])

        new_hash = subprocess.check_output(cmd, env=env).decode().strip()
        prev_commit = new_hash
        new_commits.append(new_hash)

    # Point main to the new commit tip
    final_hash = new_commits[-1]
    subprocess.check_call(["git", "update-ref", "refs/heads/main", final_hash])
    subprocess.check_call(["git", "checkout", "main"])
    subprocess.check_call(["git", "reset", "--hard", final_hash])

    print("Successfully rewritten commit history.")
    print(f"New HEAD: {final_hash}")

if __name__ == "__main__":
    main()
