"""Bounded, encrypted Matrix attachments; never fetch a sender supplied HTTP URL."""
import hashlib
import io
import mimetypes
import os
import re
import stat
from pathlib import Path
from urllib.parse import quote, urlsplit

import aiohttp
from nio import UploadResponse
from nio.crypto.attachments import decrypt_attachment

MAX_BYTES = 20 * 1024 * 1024


def safe_name(value):
    value = str(value).replace("\\", "/").rsplit("/", 1)[-1]
    return "".join(c for c in value if c.isalnum() or c in " ._-")[:120].strip(" .") or "attachment"


def mime_type(value, name):
    if isinstance(value, str) and re.fullmatch(r"[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+", value):
        return value.lower()
    return mimetypes.guess_type(name)[0] or "application/octet-stream"


async def download(client, root, event, server_name):
    content = event.source["content"]
    if content.get("msgtype") not in {"m.image", "m.file"}:
        raise ValueError("unsupported_attachment_type")
    encrypted = content.get("file")
    if not isinstance(encrypted, dict) or encrypted.get("v") != "v2":
        raise ValueError("attachment_encryption_required")
    try:
        source = encrypted.get("url", "")
        if not isinstance(source, str):
            raise ValueError()
        uri = urlsplit(source)
    except ValueError:
        raise ValueError("invalid_attachment_source") from None
    if (uri.scheme != "mxc" or uri.netloc != server_name or uri.query or uri.fragment or
            not re.fullmatch(r"/[A-Za-z0-9_-]+", uri.path)):
        raise ValueError("invalid_attachment_source")
    try:
        key, checksum, iv = encrypted["key"]["k"], encrypted["hashes"]["sha256"], encrypted["iv"]
        if not all(isinstance(v, str) and len(v) <= 128 for v in (key, checksum, iv)):
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise ValueError("invalid_attachment_encryption") from None
    url = (client.homeserver + "/_matrix/client/v1/media/download/" +
           quote(uri.netloc, safe="") + uri.path)
    # Stream against the actual bytes, not the untrusted Matrix info.size field.
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=45)) as session:
        async with session.get(url, headers={"Authorization": "Bearer " + client.access_token},
                               params={"allow_remote": "false"}, allow_redirects=False) as response:
            if response.status in {400, 403, 404, 413}:
                raise ValueError("attachment_unavailable")
            response.raise_for_status()
            if response.status != 200:
                raise ValueError("invalid_attachment_response")
            if response.content_length is not None and response.content_length > MAX_BYTES:
                raise ValueError("attachment_too_large")
            ciphertext = bytearray()
            async for chunk in response.content.iter_chunked(65536):
                if len(ciphertext) + len(chunk) > MAX_BYTES:
                    raise ValueError("attachment_too_large")
                ciphertext.extend(chunk)
    try:
        plaintext = decrypt_attachment(bytes(ciphertext), key, checksum, iv)
    except Exception:
        raise ValueError("attachment_integrity_failed") from None
    name = safe_name(content.get("filename") or content.get("body") or "attachment")
    directory = root / "incoming" / hashlib.sha256(event.event_id.encode()).hexdigest()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / name
    temporary = directory / ".download"
    with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600), "wb") as stream:
        stream.write(plaintext)
    os.replace(temporary, path)
    return {"path": str(path), "name": name, "mime_type": mime_type(content.get("info", {}).get("mimetype"), name),
            "size": len(plaintext), "kind": "image" if content["msgtype"] == "m.image" else "file"}


def outgoing(root, attachment):
    if not isinstance(attachment, dict) or set(attachment) - {"path", "name", "mime_type"}:
        raise ValueError("invalid_attachment")
    path_value = attachment.get("path")
    if not isinstance(path_value, str):
        raise ValueError("invalid_attachment_path")
    path = Path(path_value)
    directory = (root / "outgoing").resolve()
    if not path.is_absolute() or path.parent.resolve() != directory or path.is_symlink():
        raise ValueError("invalid_attachment_path")
    # Only explicitly staged files; no arbitrary local paths or hard-linked secrets.
    with os.fdopen(os.open(directory / path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ValueError("invalid_attachment_path")
        if metadata.st_size > MAX_BYTES:
            raise ValueError("attachment_too_large")
        data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("attachment_too_large")
    name = safe_name(attachment.get("name") or path.name)
    mime = mime_type(attachment.get("mime_type"), name)
    return data, name, mime


async def upload(client, data, name, mime):
    import asyncio
    response, encryption = await asyncio.wait_for(client.upload(
        io.BytesIO(data), content_type="application/octet-stream", encrypt=True, filesize=len(data)), 60)
    if not isinstance(response, UploadResponse) or not encryption:
        raise RuntimeError("attachment_upload_failed")
    return {"msgtype": "m.image" if mime.startswith("image/") else "m.file", "body": name,
            "filename": name, "file": {**encryption, "url": response.content_uri},
            "info": {"mimetype": mime, "size": len(data)}}
