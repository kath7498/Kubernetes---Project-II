import uuid
import asyncio
import os
import socket
import random
import ipaddress
import time
from pathlib import Path

import aiohttp
from aiohttp import web
from fortunes import FORTUNES

# Configuration

POD_IP = os.environ.get("POD_IP", "127.0.0.1")
WEB_PORT = int(os.environ.get("WEB_PORT", "8080"))

POD_NAME = os.environ.get("POD_NAME", "bully-app-0")

# Extract stable ID from the StatefulSet pod name
POD_ID = int(POD_NAME.rsplit("-", 1)[1])

REPLICAS = 3 # 3 pods will be initialized

STATIC_DIR = Path(__file__).parent / "static"

CHECK_INTERVAL = 2
ELECTION_TIMEOUT = 2
COORDINATOR_TIMEOUT = 3

# Bully state
leader_id = None
leader_ip = None
is_leader = False
election_task = None

# State for the currently active election
active_election = None

def set_leader(new_id, new_ip):
    """Update the local view of the leader in one place."""
    global leader_id, leader_ip, is_leader

    leader_id = new_id
    leader_ip = new_ip
    is_leader = (new_id == POD_ID)
    
# Fortune Cookie website


async def index(request):
    if not is_leader:
        return web.Response(
            text="This pod is not the leader",
            status=503
        )

    return web.FileResponse(STATIC_DIR / "index.html")


async def get_fortune(request):
    if not is_leader:
        return web.json_response(
            {"error": "This pod is not the leader"},
            status=503
        )

    return web.json_response({
        "fortune": random.choice(FORTUNES)
    })


# Pod discovery


def get_pod_id(hostname):
    name = hostname.split(".")[0]
    return int(name.rsplit("-", 1)[1])


async def discover_pods():
    """Find active pods using their stable DNS names."""

    async def check_pod(pod_id, session):
        hostname = f"bully-app-{pod_id}.bully-service"
        url = f"http://{hostname}:{WEB_PORT}/pod_id"

        try:
            async with session.get(url) as response:
                if response.status != 200:
                    return None

                reported_id = await response.json()

                if reported_id == pod_id:
                    return hostname

        except (aiohttp.ClientError,
                asyncio.TimeoutError,
                OSError):
            return None

        return None

    timeout = aiohttp.ClientTimeout(total=1)

    async with aiohttp.ClientSession(timeout=timeout) as session:
        tasks = [
            check_pod(i, session)
            for i in range(REPLICAS)
            if i != POD_ID
        ]

        results = await asyncio.gather(*tasks)

    return [host for host in results if host is not None]



async def send_message(ip, endpoint, data):
    """Send an asynchronous HTTP message to another pod."""
    url = f"http://{ip}:{WEB_PORT}{endpoint}"

    try:
        timeout = aiohttp.ClientTimeout(total=1)

        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.post(url, json=data) as response:
                return response.status == 200

    except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
        print(f"Cannot reach {ip} at {endpoint}")
        return False

# Bully election

def start_election():
    global election_task

    if election_task is None or election_task.done():
        election_task = asyncio.create_task(run_election())


async def run_election():
    global active_election
    
    try:
        while True:
            election_id = uuid.uuid4().hex
            
            election = {
                "id": election_id,
                "answer_event": asyncio.Event(),
                "coordinator_event": asyncio.Event()
            }
            
            active_election = election
            
            print(f"[{time.time():.3f}] Pod {POD_ID}: ELECTION started ({election_id[:8]})")

            peers = await discover_pods()
            
            if election["coordinator_event"].is_set():
                return

            higher_pods = [
                host for host in peers
                if get_pod_id(host) > POD_ID
            ]

            if not higher_pods:
                # One short confirmation avoids electing ourselves because of
                # a single missed discovery result.
                if POD_ID < REPLICAS - 1:
                    await asyncio.sleep(0.3)
                    peers = await discover_pods()
                    if election["coordinator_event"].is_set():
                        return
                    if any(get_pod_id(host) > POD_ID for host in peers):
                        continue
                await become_leader()
                return

            # Send ELECTION to all higher-ID pods
            results = await asyncio.gather(*[
                send_message(host, "/receive_election", {
                    "id": POD_ID,
                    "ip": POD_IP,
                    "election_id": election_id
                })
                for host in higher_pods
            ])

            if election["coordinator_event"].is_set():
                return

            # A successful POST proves that a higher-ID pod handled ELECTION,
            # even if its separate ANSWER callback was lost.
            if any(results):
                election["answer_event"].set()
            
            try:
                # Wait for ANSWER from a higher pod
                await asyncio.wait_for(
                    election["answer_event"].wait(),
                    timeout=ELECTION_TIMEOUT
                )
            except asyncio.TimeoutError:
                if election["coordinator_event"].is_set():
                    return

                # Never promote ourselves while a higher-ID pod still responds.
                peers = await discover_pods()
                if election["coordinator_event"].is_set():
                    return
                if any(get_pod_id(host) > POD_ID for host in peers):
                    print("Higher-ID pod reachable; retrying election")
                    await asyncio.sleep(0.3)
                    continue

                await become_leader()
                return

            if election["coordinator_event"].is_set():
                return

            # A higher pod is active.
            # Wait for its COORDINATOR message.
            try:
                await asyncio.wait_for(
                    election["coordinator_event"].wait(),
                    timeout=COORDINATOR_TIMEOUT
                )
                return

            except asyncio.TimeoutError:
                print("Coordinator timeout. Retrying election.")
                
    finally:
        active_election = None


async def become_leader():
    set_leader(POD_ID, POD_IP)

    election = active_election
    if election is not None:
        election["coordinator_event"].set()

    print(f"[{time.time():.3f}] *** Pod {POD_ID} is LEADER ***")

    peers = await discover_pods()
    await asyncio.gather(*[
        send_message(host, "/receive_coordinator", {
            "id": POD_ID,
            "ip": POD_IP,
        })
        for host in peers
    ])

# Bully API endpoints

async def pod_id(request):
    return web.json_response(POD_ID)


async def receive_election(request):
    data = await request.json()
    sender_id = int(data["id"])
    sender_ip = data["ip"]
    election_id = data["election_id"]

    print(f"Received ELECTION from {sender_id} ({election_id[:8]})")

    if sender_id < POD_ID:
        # Tell sender that a higher pod is alive
        await send_message(sender_ip, "/receive_answer", {
            "id": POD_ID,
            "ip": POD_IP,
            "election_id": election_id
        })

        if is_leader:
            # An existing leader can announce itself
            await send_message(sender_ip, "/receive_coordinator", {
                "id": POD_ID,
                "ip": POD_IP
            })
        else:
            start_election()

    return web.json_response({"ok": True})


async def receive_answer(request):
    data = await request.json()
    sender_id = int(data["id"])
    received_election_id = data.get("election_id")
    election = active_election

    accepted = (
        election is not None
        and sender_id > POD_ID
        and received_election_id == election["id"]
    )

    if accepted:
        election["answer_event"].set()
        print(f"Accepted ANSWER from {sender_id}")
    else:
        print(f"Ignored outdated ANSWER from {sender_id}")

    return web.json_response({"accepted": accepted})


async def receive_coordinator(request):
    data = await request.json()
    new_leader_id = int(data["id"])
    new_leader_ip = data["ip"]

    # This pod has a higher ID and must initiate an election itself.
    if new_leader_id < POD_ID:
        start_election()
        return web.json_response({"accepted": False})

    # A delayed announcement from a lower-ID leader must not replace a
    # higher-ID leader which is still alive and declares itself leader.
    previous_id, previous_ip = leader_id, leader_ip
    if previous_id is not None and new_leader_id < previous_id:
        previous_alive = await leader_is_alive()
        if (previous_alive and
                leader_id == previous_id and leader_ip == previous_ip):
            print(f"Ignoring stale COORDINATOR from {new_leader_id}; "
                  f"leader {previous_id} is still active")
            return web.json_response({"accepted": False})

    set_leader(new_leader_id, new_leader_ip)

    election = active_election
    if election is not None:
        election["coordinator_event"].set()
        election["answer_event"].set()

    print(f"[{time.time():.3f}] New leader: {leader_id}")
    return web.json_response({"accepted": True})


async def status(request):
    return web.json_response({
        "pod_id": POD_ID,
        "pod_ip": POD_IP,
        "leader_id": leader_id,
        "leader_ip": leader_ip,
        "is_leader": is_leader
    })
    
async def readiness(request):
    if is_leader:
        return web.Response(text="Ready")

    return web.Response(
        text="Not the leader",
        status=503
    )

# Failure detection

async def leader_is_alive():
    if leader_ip is None or leader_id is None:
        return False

    if leader_ip == POD_IP:
        return is_leader and leader_id == POD_ID

    url = f"http://{leader_ip}:{WEB_PORT}/status"

    try:
        timeout = aiohttp.ClientTimeout(total=1)

        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(url) as response:
                if response.status != 200:
                    return False

                data = await response.json()
                return (
                    data["pod_id"] == leader_id
                    and data["leader_id"] == leader_id
                    and data["is_leader"] is True
                    )

    except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
        return False


async def run_bully():
    await asyncio.sleep(3)

    while True:
        peers = await discover_pods()

        highest_id = max(
            [POD_ID] +
            [get_pod_id(host) for host in peers]
        )

        election_running = (
            election_task is not None
            and not election_task.done()
        )

        if not election_running:
            if leader_id is None:
                start_election()

            elif highest_id > leader_id:
                start_election()

            elif not await leader_is_alive():
                print(f"[{time.time():.3f}] Leader failure detected")
                start_election()

        await asyncio.sleep(CHECK_INTERVAL)

# Background task lifecycle

async def background_tasks(app):
    task = asyncio.create_task(run_bully())

    yield

    task.cancel()

    if election_task is not None:
        election_task.cancel()

    await asyncio.gather(
        task,
        *([election_task] if election_task is not None else []),
        return_exceptions=True
    )

# Start web server

if __name__ == "__main__":
    app = web.Application()

    # Bully endpoints
    app.router.add_get("/pod_id", pod_id)
    app.router.add_post("/receive_answer", receive_answer)
    app.router.add_post("/receive_election", receive_election)
    app.router.add_post("/receive_coordinator", receive_coordinator)
    app.router.add_get("/status", status)
    app.router.add_get("/ready", readiness)

    # Fortune Cookie endpoints
    app.router.add_get("/", index)
    app.router.add_get("/fortune", get_fortune)
    app.router.add_static("/static/", path=STATIC_DIR)

    # Start Bully background task
    app.cleanup_ctx.append(background_tasks)

    web.run_app(app, host="0.0.0.0", port=WEB_PORT)
