import argparse

from .config import load
from .train import run


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--config", required=True)
    p.add_argument("--smoke", action="store_true")
    p.add_argument("--device", default="cpu")
    a = p.parse_args(argv)
    cfg = load(a.config)
    if a.smoke:
        cfg = cfg.smoke()
    print(run(cfg, a.device))
