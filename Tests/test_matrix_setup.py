"""Bootstrap must refuse replacing any used installation."""
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
spec = importlib.util.spec_from_file_location('matrix_setup', Path(__file__).parents[1] / 'matrix/setup.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    (root / 'matrix').mkdir()
    server = sqlite3.connect(root / 'matrix/homeserver.sqlite')
    server.executescript('CREATE TABLE events(type TEXT); CREATE TABLE devices(user_id TEXT);')
    bridge = sqlite3.connect(root / 'bridge.sqlite')
    bridge.executescript('CREATE TABLE tasks(id TEXT); CREATE TABLE outbox(id TEXT); CREATE TABLE inbound_events(id TEXT);')
    setup.verify_unused(root)
    for database, insert, clear in [
        (server,"INSERT INTO events VALUES ('m.room.encrypted')",'DELETE FROM events'),
        (server,"INSERT INTO devices VALUES ('@owner:test')",'DELETE FROM devices'),
        (bridge,"INSERT INTO tasks VALUES ('pending')",'DELETE FROM tasks'),
    ]:
        database.execute(insert);database.commit()
        try:
            setup.verify_unused(root)
            raise AssertionError('Used installation was accepted')
        except RuntimeError:
            pass
        database.execute(clear);database.commit()
    setup.verify_unused(root)
    server.close();bridge.close()
print('PASS: messages, user devices and queued work prevent replacement.')
