"""Start real PostgreSQL through Indexa's launcher without shell locale variables."""
import asyncio
import os
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).parents[1] / 'matrix'))
from native_services import NativeServices, PG

async def check():
    with tempfile.TemporaryDirectory(prefix='indexa-gui-', dir='/private/tmp') as temporary:
        root = Path(temporary)
        (root/'matrix-qr').mkdir()
        (root/'pgsocket').mkdir(mode=0o700)
        data = root/'matrix-qr/postgres'
        subprocess.run([PG+'/initdb','-D',str(data),'--locale=C','--encoding=UTF8','--auth-local=peer'],
                       env={**os.environ,'LC_ALL':'C'},check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        with (data/'postgresql.conf').open('a') as f:
            f.write("\nlisten_addresses=''\nport=18767\nunix_socket_directories='"+str(root/'pgsocket')+"'\n")
        for key in list(os.environ):
            if key in {'LANG','LANGUAGE'} or key.startswith('LC_'):
                os.environ.pop(key)
        services=NativeServices(root)
        try:
            await services.postgres()
            assert services.children[0].returncode is None
        finally:
            await services.stop()
asyncio.run(check())
print('PASS: native database starts without inherited shell locale')
