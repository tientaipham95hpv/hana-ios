from __future__ import annotations

import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import Principal, require_user
from app.core.config import Settings, get_settings
from app.db.models import MediaObject
from app.db.session import get_session
from app.services.media import MediaStore

router = APIRouter(prefix="/v1", tags=["media"])


@router.get("/media/{media_id}")
async def media(
    media_id: uuid.UUID,
    principal: Principal = Depends(require_user),
    settings: Settings = Depends(get_settings),
    session: AsyncSession = Depends(get_session),
):
    item = await session.scalar(
        select(MediaObject).where(
            MediaObject.id == media_id, MediaObject.user_id == principal.user_id
        )
    )
    if item is None or item.expires_at <= datetime.now(UTC):
        raise HTTPException(
            status_code=404,
            detail={
                "error": {
                    "code": "NOT_FOUND",
                    "message": "Media khong con kha dung",
                    "retryable": False,
                    "details": {},
                }
            },
        )
    path = MediaStore(settings).resolve(item.storage_key)
    if not path.is_file():
        raise HTTPException(
            status_code=404,
            detail={
                "error": {
                    "code": "NOT_FOUND",
                    "message": "Media khong con kha dung",
                    "retryable": False,
                    "details": {},
                }
            },
        )
    return FileResponse(path, media_type=item.mime, headers={"Cache-Control": "private, no-store"})
