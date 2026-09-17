from __future__ import annotations

import uuid

from fastapi import Depends, Header, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings, get_settings
from app.db.models import User

DEV_USER_ID = uuid.UUID("00000000-0000-7000-8000-000000000001")


class Principal(BaseModel):
    user_id: uuid.UUID
    device_id: str = "local-android"


async def require_user(
    authorization: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
) -> Principal:
    if settings.app_env in {"local", "test"} and settings.dev_auth_bypass:
        return Principal(user_id=DEV_USER_ID)
    if not authorization:
        raise HTTPException(status_code=401, detail={"code": "AUTH_TOKEN_EXPIRED"})
    raise HTTPException(status_code=501, detail={"code": "AUTH_NOT_CONFIGURED"})


async def ensure_dev_owner(session: AsyncSession) -> None:
    if await session.scalar(select(User.id).where(User.id == DEV_USER_ID)) is None:
        session.add(User(id=DEV_USER_ID, username="owner", display_name="Owner", is_owner=True))
        await session.commit()
