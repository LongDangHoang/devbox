import torch
from torch import nn

from .config import Config


def run(config: Config, device: str) -> dict[str, float]:
    torch.manual_seed(config.seed)
    d = 8
    x = torch.randn(config.n_data, d, device=device)
    y = x.sum(dim=1, keepdim=True)
    layers: list[nn.Module] = [nn.Linear(d, config.width), nn.ReLU()]
    for _ in range(config.depth - 1):
        layers += [nn.Linear(config.width, config.width), nn.ReLU()]
    model = nn.Sequential(*layers, nn.Linear(config.width, 1)).to(device)
    fwd = torch.compile(model) if config.compile else model
    opt = torch.optim.Adam(model.parameters(), lr=config.lr)

    def loss_fn(idx: torch.Tensor) -> torch.Tensor:
        with torch.autocast(device, dtype=torch.bfloat16, enabled=config.bf16):
            return nn.functional.mse_loss(fwd(x[idx]).float(), y[idx])

    for _ in range(config.steps):
        idx = torch.randint(0, config.n_data, (config.batch_size,), device=device)
        opt.zero_grad()
        loss_fn(idx).backward()
        opt.step()
    with torch.no_grad():
        ev = [
            loss_fn(torch.randint(0, config.n_data, (config.batch_size,), device=device)).item()
            for _ in range(config.eval_steps)
        ]
    return {"eval_loss": sum(ev) / len(ev)}
