from __future__ import annotations

import argparse
import asyncio

from app.api.deps import ensure_dev_owner
from app.db.session import SessionFactory


async def ensure_owner() -> None:
    async with SessionFactory() as session:
        await ensure_dev_owner(session)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["ensure-dev-owner"])
    args = parser.parse_args()
    if args.command == "ensure-dev-owner":
        asyncio.run(ensure_owner())


if __name__ == "__main__":
    main()
