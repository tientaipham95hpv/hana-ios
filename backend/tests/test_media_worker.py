from datetime import UTC, datetime
from uuid import uuid4

import pytest

from app.core.config import Settings
from app.services.media import MediaStore
from app.workers.settings import WorkerSettings


def test_media_is_private_keyed_ttl_content(tmp_path):
    store = MediaStore(Settings(app_env="test", media_root=tmp_path))
    before = datetime.now(UTC)
    saved = store.write(
        media_id=uuid4(),
        kind="tts",
        data=b"audio",
        suffix=".mp3",
        ttl_s=60,
    )
    assert saved.path.read_bytes() == b"audio"
    assert saved.expires_at >= before
    assert saved.expires_at.timestamp() - before.timestamp() <= 61
    assert not saved.key.startswith("/")


@pytest.mark.parametrize("key", ["../secret", "tts/../../secret", "/absolute"])
def test_media_resolve_rejects_traversal(tmp_path, key):
    store = MediaStore(Settings(app_env="test", media_root=tmp_path))
    with pytest.raises(ValueError):
        store.resolve(key)


def test_worker_retry_is_bounded():
    assert WorkerSettings.max_tries == 3
