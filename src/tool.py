import subprocess


def run(args):
    return subprocess.run(args, check=True)
