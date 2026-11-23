import pytest

from tvlab.lab import DEFAULT_PORTS, Lab


@pytest.fixture
async def lab():
    ports = {name: dict.fromkeys(schemes, 0) for name, schemes in DEFAULT_PORTS.items()}
    async with Lab(ports=ports, control_port=0, ssdp_port=0, wol_port=0) as instance:
        yield instance
