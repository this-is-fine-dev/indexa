import importlib.util
import io
import json
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("matrix_service", Path(__file__).parents[1] / "matrix/service.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

credentials = {name: "synthetic-credential-not-a-real-secret" for name in
               ["matrix-transport-key", "matrix-bot-token", "matrix-pickle-key"]}
assert module.read_credentials(io.BytesIO(json.dumps(credentials).encode())) == credentials
for invalid in [dict(credentials, unrelated_password="forbidden"), {}, ["secret"]]:
    try:
        module.read_credentials(io.BytesIO(json.dumps(invalid).encode()))
    except ValueError:
        pass
    else:
        raise AssertionError("Unexpected secret scope accepted")

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "journal.sqlite"
    journal = module.Journal(path)
    event = {"id": "$synthetic", "sender": "@owner:test", "room": "!room:test", "text": "żółć", "timestamp": 1}
    journal.accept(event)
    journal.accept(event)
    assert len(journal.pending()) == 1
    restarted = module.Journal(path)
    assert restarted.pending()[0] == event
    restarted.ack(event["id"])
    restarted.accept(event)
    assert restarted.pending() == []
    journal.sent("txn-1", "digest", "$event-1")
    assert restarted.delivery("txn-1", "digest") == "$event-1"
    try:
        restarted.delivery("txn-1", "different-payload")
    except ValueError:
        pass
    else:
        raise AssertionError("transaction ID reuse accepted a different payload")
print("PASS: durable inbox, replay dedupe, send transaction identity")

# Exercise the real device-list handler against the installed nio API.
import asyncio
from nio.crypto import OlmDevice
async def device_list_check():
    with tempfile.TemporaryDirectory() as directory:
        config = {"owner_user": "@owner:test", "bot_user": "@indexa:test", "device_id": "BOT", "room_id": "!room:test"}
        transport = module.Transport(config, Path(directory), credentials)
        device = OlmDevice("@owner:test", "PHONE", {"ed25519": "synthetic-fingerprint", "curve25519": "synthetic-curve"})
        transport.client.device_store.add(device)
        try:
            response = await transport.devices(None)
            assert json.loads(response.body)["devices"] == [{"id": "PHONE", "key": "synthetic-fingerprint", "name": "PHONE", "verified": False}]
        finally:
            await transport.client.close()
asyncio.run(device_list_check())
print("PASS: device list uses supported nio trust state")

async def inbox_wakes_on_message_check():
    from types import SimpleNamespace
    from nio import RoomMessageText
    with tempfile.TemporaryDirectory() as directory:
        config = {"owner_user": "@owner:test", "bot_user": "@indexa:test", "device_id": "BOT", "room_id": "!room:test"}
        transport = module.Transport(config, Path(directory), credentials)
        waiting = asyncio.create_task(transport.events(None))
        try:
            await asyncio.sleep(0.02)
            assert not waiting.done(), 'Empty inbox must wait for a message instead of requiring another poll'
            event = RoomMessageText.from_dict({"type": "m.room.message", "event_id": "$wake", "sender": config["owner_user"],
                "origin_server_ts": 1000, "content": {"msgtype": "m.text", "body": "synthetic"}})
            event.decrypted = True
            await transport.message(SimpleNamespace(room_id=config["room_id"], encrypted=True), event)
            response = await asyncio.wait_for(waiting, 0.5)
            assert json.loads(response.body)['events'][0]['id'] == '$wake'
            # Persisted, unacknowledged backlog returns immediately, including after restart.
            response = await asyncio.wait_for(transport.events(None), 0.5)
            assert len(json.loads(response.body)['events']) == 1
            transport.journal.ack('$wake')
            waiting = asyncio.create_task(transport.events(None))
            await asyncio.sleep(0.02)
            assert not waiting.done(), 'Acknowledged messages must not leave a busy-loop wakeup'
        finally:
            waiting.cancel()
            await asyncio.gather(waiting, return_exceptions=True)
            await transport.client.close()
        from unittest.mock import patch
        async def expire(awaitable, timeout):
            assert timeout == 10
            awaitable.close()
            raise asyncio.TimeoutError
        with patch.object(module.asyncio, 'wait_for', expire):
            assert json.loads((await transport.events(None)).body)['events'] == []
asyncio.run(inbox_wakes_on_message_check())
print('PASS: inbox wakes immediately, retains unacknowledged messages and waits after ack')

async def restart_with_unchanged_cursor_check():
    from nio import SyncResponse
    with tempfile.TemporaryDirectory() as directory:
        config = {"owner_user": "@owner:test", "bot_user": "@indexa:test", "device_id": "BOT", "room_id": "!room:test"}
        transport = module.Transport(config, Path(directory), credentials)
        transport.journal.put('sync_token', 'same-token')
        calls = 0
        async def response_from_server(**kwargs):
            nonlocal calls
            calls += 1
            if calls > 1:
                raise asyncio.CancelledError
            assert kwargs['since'] == 'same-token' and kwargs['full_state'] is True
            response = SyncResponse.from_dict({'next_batch': 'same-token', 'rooms': {'join': {'!room:test': {
                'timeline': {'events': [], 'limited': False, 'prev_batch': 'previous'}, 'state': {'events': []},
                'ephemeral': {'events': []}, 'account_data': {'events': []}}}}})
            assert isinstance(response, SyncResponse)
            # Use nio's real duplicate-response guard and room reconstruction.
            await transport.client.receive_response(response)
            return response
        async def no_network(*args, **kwargs):
            pass
        transport.client.sync = response_from_server
        transport.client.keys_upload = no_network
        transport.client.keys_query = no_network
        transport.client.keys_claim = no_network
        transport.client.send_to_device_messages = no_network
        try:
            try:
                await transport.sync()
            except asyncio.CancelledError:
                pass
            assert transport.ready, 'Restart skipped full room state when sync token did not change'
            assert transport.journal.get('sync_token') == 'same-token'
        finally:
            await transport.client.close()
asyncio.run(restart_with_unchanged_cursor_check())
print('PASS: restart reconstructs room state even when sync token is unchanged')

async def readiness_does_not_reserve_transaction_check():
    from types import SimpleNamespace
    with tempfile.TemporaryDirectory() as directory:
        config = {"owner_user": "@owner:test", "bot_user": "@indexa:test", "device_id": "BOT", "room_id": "!room:test"}
        transport = module.Transport(config, Path(directory), credentials)
        async def data():
            return {"id":"same-transaction", "room":"!room:test", "text":"synthetic"}
        try:
            response = await transport.send(SimpleNamespace(json=data))
            assert response.status == 503 and json.loads(response.body)['sent'] is False
            assert transport.journal.db.execute('SELECT count(*) FROM deliveries').fetchone()[0] == 0
        finally:
            await transport.client.close()
asyncio.run(readiness_does_not_reserve_transaction_check())
print('PASS: unavailable Matrix proves no send attempt occurred')

async def limited_sync_keeps_cursor_and_loop_alive_check():
    from unittest.mock import patch
    with tempfile.TemporaryDirectory() as directory:
        config = {"owner_user": "@owner:test", "bot_user": "@indexa:test", "device_id": "BOT", "room_id": "!room:test"}
        transport = module.Transport(config, Path(directory), credentials)
        transport.journal.put('sync_token', 'durable-before-gap')
        async def response_from_server(**kwargs):
            response = module.SyncResponse.from_dict({'next_batch': 'after-gap', 'rooms': {'join': {'!room:test': {
                'timeline': {'events': [], 'limited': True, 'prev_batch': 'previous'}, 'state': {'events': []},
                'ephemeral': {'events': []}, 'account_data': {'events': []}}}}})
            await transport.client.receive_response(response)
            return response
        async def no_network(*args, **kwargs):
            pass
        async def stop_at_retry(delay):
            assert delay == 30
            raise asyncio.CancelledError
        transport.client.sync = response_from_server
        transport.client.keys_upload = no_network
        transport.client.keys_query = no_network
        transport.client.keys_claim = no_network
        transport.client.send_to_device_messages = no_network
        try:
            with patch.object(module.asyncio, 'sleep', stop_at_retry):
                try:
                    await transport.sync()
                except asyncio.CancelledError:
                    pass
                else:
                    raise AssertionError('Sync silently died instead of keeping its loop alive')
            assert transport.journal.get('sync_token') == 'durable-before-gap'
            assert transport.problem == 'matrix_timeline_gap_requires_review'
            assert not transport.ready
        finally:
            await transport.client.close()
asyncio.run(limited_sync_keeps_cursor_and_loop_alive_check())
print('PASS: timeline gap keeps durable cursor and does not kill sync loop')

async def bounded_native_logs_check():
    import sys
    from logging.handlers import RotatingFileHandler
    sys.path.insert(0, str(Path(__file__).parents[1] / 'matrix'))
    from native_services import NativeServices
    with tempfile.TemporaryDirectory() as directory:
        stream = asyncio.StreamReader()
        stream.feed_data(b'x' * 12000)
        stream.feed_eof()
        handler = RotatingFileHandler(Path(directory) / 'service.log', maxBytes=10000, backupCount=2)
        await NativeServices.collect_log(stream, handler)
        handler.close()
        files = list(Path(directory).glob('service.log*'))
        assert len(files) <= 3 and all(path.stat().st_size <= 10000 for path in files)
        assert sum(path.stat().st_size for path in files) >= 12000
asyncio.run(bounded_native_logs_check())
print('PASS: bounded native subprocess log collection')

async def typing_check():
    from types import SimpleNamespace
    from nio import RoomTypingResponse, RoomTypingError
    from aiohttp import web
    calls = []
    reply = RoomTypingResponse('!private:test')
    async def room_typing(room, **kwargs):
        calls.append((room, kwargs))
        return reply
    transport = module.Transport.__new__(module.Transport)
    transport.config = {'room_id': '!private:test'}
    transport.ready = True
    transport.client = SimpleNamespace(room_typing=room_typing)
    async def request(value):
        async def body(): return value
        return await transport.typing(SimpleNamespace(json=body))
    for state in (True, True, False):
        assert (await request({'typing': state})).status == 200
    assert calls == [('!private:test', {'typing_state': state, 'timeout': 25000}) for state in (True, True, False)]
    for invalid in ({'typing': 1}, {'typing': 'true'}, {'typing': True, 'room': '!other:test'}, [], {}):
        try: await request(invalid)
        except web.HTTPBadRequest: pass
        else: raise AssertionError('Invalid typing payload accepted')
    transport.ready = False
    try: await request({'typing': True})
    except web.HTTPServiceUnavailable: pass
    else: raise AssertionError('Typing started before ready')
    assert (await request({'typing': False})).status == 200
    reply = RoomTypingError('failed', 'M_UNKNOWN', room_id='!private:test')
    try: await request({'typing': False})
    except web.HTTPBadGateway: pass
    else: raise AssertionError('Typing failure reported as success')
asyncio.run(typing_check())
print('PASS: typing start/renew/stop, fixed room, validation and server failures')
