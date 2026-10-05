from pathlib import Path
from typing import Literal, get_args

import yaml
from pydantic import BaseModel, Field

# Allowlist; smoke uses the first (smallest). These bounds are guardrails, not a security
# control: the agent can edit this file. The Modal workspace spend limit is the backstop.
Gpu = Literal["T4", "L4", "A10G", "A100", "H100"]
GPUS: tuple[str, ...] = get_args(Gpu)


class Config(BaseModel, extra="forbid"):
    name: str
    gpu: Gpu = "T4"
    timeout_s: int = Field(3600, ge=60, le=4 * 3600)
    max_containers: int = Field(1, ge=1, le=4)
    width: int = 256
    depth: int = 4
    steps: int = 200
    batch_size: int = 64
    n_data: int = 4096
    eval_steps: int = 10
    lr: float = 1e-3
    seed: int = 0
    # GPU-only features: off in local CPU smoke, on in the Modal GPU smoke
    bf16: bool = False
    compile: bool = False

    def smoke(self, keep_gpu_features: bool = False) -> "Config":
        return self.model_copy(
            update={
                "width": 16,
                "depth": 1,
                "steps": 3,
                "batch_size": 8,
                "n_data": 64,
                "eval_steps": 1,
                "bf16": self.bf16 and keep_gpu_features,
                "compile": self.compile and keep_gpu_features,
            }
        )


def load(path: str | Path) -> Config:
    return Config.model_validate(yaml.safe_load(Path(path).read_text()))
