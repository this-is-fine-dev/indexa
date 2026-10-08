"""Run by MCPTests against a synthetic module; never accesses Apple Notes."""
import asyncio
import json
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client, create_mcp_http_client


async def main():
    config = json.load(sys.stdin)
    async with create_mcp_http_client(headers={'Authorization': 'Bearer ' + config['token']}) as http:
        async with streamable_http_client(config['url'], http_client=http) as streams:
            read, write = streams[:2]
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                assert [tool.name for tool in tools.tools] == ['test_read']
                result = await session.call_tool('test_read', {})
                assert not result.is_error and result.content[0].text == 'ok'
    print('PASS: Hermes MCP SDK initialize/list/call/disconnect')


if __name__ == '__main__':
    asyncio.run(main())
