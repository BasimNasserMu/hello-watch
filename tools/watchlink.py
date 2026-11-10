"""watchlink — talk to a paired Apple Watch's lockdownd *through the iPhone* over USB.

The iPhone's com.apple.companion_proxy service can forward any watch port. This wraps
pymobiledevice3's LockdownClient so every service connection (installation_proxy, afc, ...)
is tunnelled through that proxy, giving Windows the same "install over USB" path the
iPhone has.

Usage:
    python tools/watchlink.py info
    python tools/watchlink.py pair            # creates a watch pair record (watch may prompt)
    python tools/watchlink.py install X.ipa   # installs the IPA directly on the watch
    python tools/watchlink.py apps            # lists user apps on the watch

Pair records for the watch live in ~/.hellowatch/watch-pairing (never touches the iPhone's).
"""
import argparse
import asyncio
import logging
from pathlib import Path

from pymobiledevice3.lockdown import LockdownClient, create_using_usbmux
from pymobiledevice3.service_connection import ServiceConnection
from pymobiledevice3.services.companion import CompanionProxyService

PAIR_DIR = Path.home() / ".hellowatch" / "watch-pairing"
LOCKDOWN_PORT = 62078
log = logging.getLogger("watchlink")

# --- com.apple.streaming_zip_conduit (what Xcode uses; the watch has no AFC) -------------------
# Ported from go-ios ios/zipconduit (MIT). The device wants a "streaming zip": local file headers
# only, STORE (no compression), no data descriptors, META-INF/com.apple.ZipMetadata.plist first,
# then just the central-directory signature as an end marker.
_ZIP_EXTRA = bytes.fromhex("55540D0007F3A2EC60F6A2EC60F3A2EC6075780B000104F50100000414000000")
_CENTRAL_DIR_SIG = b"PK\x01\x02"


def _zip_local_header(name: str, size: int = 0, crc: int = 0) -> bytes:
    import struct

    n = name.encode()
    return struct.pack(
        "<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, 0xBDEF, 0x52EC, crc, size, size, len(n), len(_ZIP_EXTRA)
    ) + n + _ZIP_EXTRA


async def zip_conduit_install(watch, ipa_path: Path) -> None:
    import plistlib
    import zipfile
    import zlib

    with zipfile.ZipFile(ipa_path) as ipa:
        entries = ipa.infolist()
        total = sum(e.file_size for e in entries)
        conn = await watch.start_lockdown_service("com.apple.streaming_zip_conduit")
        await conn.send_plist({
            "InstallTransferredDirectory": 1,
            "UserInitiatedTransfer": 0,
            "MediaSubdir": f"PublicStaging/{ipa_path.name}",
            "InstallOptionsDictionary": {
                "DisableDeltaTransfer": 1,
                "InstallDeltaTypeKey": "InstallDeltaTypeSparseIPAFiles",
                "IsUserInitiated": 1,
                "PackageType": "Customer",
                "PreferWifi": 1,
            },
        })
        meta = plistlib.dumps({
            "RecordCount": 2 + len(entries),
            "StandardDirectoryPerms": 16877,
            "StandardFilePerms": -32348,
            "TotalUncompressedBytes": total,
            "Version": 2,
        })
        await conn.sendall(_zip_local_header("META-INF/"))
        await conn.sendall(_zip_local_header("META-INF/com.apple.ZipMetadata.plist", len(meta), zlib.crc32(meta)) + meta)
        for e in entries:
            if e.is_dir():
                await conn.sendall(_zip_local_header(e.filename))
            else:
                data = ipa.read(e)
                await conn.sendall(_zip_local_header(e.filename, len(data), e.CRC) + data)
        await conn.sendall(_CENTRAL_DIR_SIG)
        log.info("streamed %d entries (%d bytes), waiting for install…", len(entries), total)

        while True:
            msg = await conn.recv_plist()
            if msg.get("Status") == "DataComplete":
                print("Install complete.")
                return
            prog = msg.get("InstallProgressDict", {})
            if "Error" in prog:
                raise SystemExit(f"Install failed: {prog.get('Error')} — {prog.get('ErrorDescription')}")
            log.info("  %s %s%%", prog.get("Status", msg), prog.get("PercentComplete", ""))


PHONE_PAIR_DIR = Path.home() / ".hellowatch" / "phone-pairing"


async def open_phone_port(phone_udid: str, port: int, host=None, ssl_context=None, strip_ssl=False):
    """Connect to a port on the iPhone, over USB (usbmux) or over the network (host)."""
    if host:
        return await ServiceConnection.create_using_tcp(
            host, port, create_connection_timeout=5, ssl_context=ssl_context, strip_ssl=strip_ssl
        )
    return await ServiceConnection.create_using_usbmux(phone_udid, port, ssl_context=ssl_context, strip_ssl=strip_ssl)


def make_watch_client_class(phone_udid: str, proxy: CompanionProxyService, host=None):
    class WatchLockdownClient(LockdownClient):
        async def create_service_connection(self, port, ssl_context=None, strip_ssl=False):
            fwd = await proxy.start_forwarding_service_port(port)
            log.info("forward watch:%s -> iPhone:%s", port, fwd)
            return await open_phone_port(phone_udid, fwd, host, ssl_context=ssl_context, strip_ssl=strip_ssl)

    return WatchLockdownClient


async def connect_phone(host=None):
    if not host:
        return await create_using_usbmux()
    from pymobiledevice3.lockdown import create_using_tcp

    records = sorted(PHONE_PAIR_DIR.glob("*.plist"))
    if not records:
        raise SystemExit(f"No iPhone pair record in {PHONE_PAIR_DIR} (save one over USB first).")
    import plistlib

    udid = records[0].stem
    log.info("connecting to iPhone %s over network at %s", udid, host)
    return await create_using_tcp(
        host,
        identifier=udid,
        autopair=False,
        pair_record=plistlib.loads(records[0].read_bytes()),
        pairing_records_cache_folder=PHONE_PAIR_DIR,
        keep_alive=True,  # Wi-Fi lockdown drops service connections without a heartbeat
    )


_heartbeat_task = None


async def connect_watch(autopair: bool, pair_timeout: float, host=None):
    global _heartbeat_task
    phone = await connect_phone(host)
    if host:
        # Over the network the iPhone drops service connections unless the host answers
        # com.apple.mobile.heartbeat Marco/Polo pings (same as SideStore's minimuxer).
        from pymobiledevice3.services.heartbeat import HeartbeatService

        _heartbeat_task = asyncio.create_task(HeartbeatService(phone).start())
        await asyncio.sleep(2)
    proxy = CompanionProxyService(phone)
    watches = await proxy.list()
    if not watches:
        raise SystemExit("No paired Apple Watch reported by the iPhone.")
    watch_udid = watches[0]
    log.info("iPhone %s -> watch %s", phone.udid, watch_udid)

    fwd = await proxy.start_forwarding_service_port(LOCKDOWN_PORT)
    log.info("forward watch:%s -> iPhone:%s", LOCKDOWN_PORT, fwd)
    service = await open_phone_port(phone.udid, fwd, host)

    PAIR_DIR.mkdir(parents=True, exist_ok=True)
    cls = make_watch_client_class(phone.udid, proxy, host)
    watch = await cls.create(
        service,
        identifier=watch_udid,
        label="watchlink",
        autopair=autopair,
        pair_timeout=pair_timeout,
        pairing_records_cache_folder=PAIR_DIR,
    )
    return watch


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["info", "pair", "install", "apps"])
    ap.add_argument("ipa", nargs="?")
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("--host", help="reach the iPhone over the network at this IP instead of USB")
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if a.v else logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    watch = await connect_watch(autopair=a.command != "info", pair_timeout=a.timeout, host=a.host)
    print("paired:", watch.paired)
    vals = watch.all_values
    for k in ["DeviceName", "ProductType", "ProductVersion", "BuildVersion", "UniqueDeviceID"]:
        print(f"  {k}: {vals.get(k)}")

    if a.command in ("install", "apps"):
        from pymobiledevice3.services.installation_proxy import InstallationProxyService

        ip = InstallationProxyService(lockdown=watch)
        if a.command == "install":
            if not a.ipa:
                raise SystemExit("install needs an .ipa path")
            await zip_conduit_install(watch, Path(a.ipa))
            print("Installed on watch:", a.ipa)
        else:
            apps = await ip.get_apps(application_type="User")
            for bid, info in apps.items():
                print(f"  {bid}  {info.get('CFBundleDisplayName') or info.get('CFBundleName')}")


if __name__ == "__main__":
    asyncio.run(main())
