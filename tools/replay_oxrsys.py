#!/usr/bin/env python3
"""Replay a stroke plan into OXRSys as its simulator's hand would.

    python3 tools/replay_oxrsys.py <plan.json> [--host 127.0.0.1] [--hz 90] [--frame-port 9950]

Sends OXRSys TrackingPackets (common/protocol/include/oxrsys/protocol/Protocol.h,
UDP port 9945, 1008 bytes, little endian, no handshake needed) at a steady
rate. Until tools/gate_replay.gd writes the plan, the right controller holds
the plan's calibration point; then each stroke is drawn with the right
trigger held, the right thumbstick is clicked whenever a stroke's boundary
flag differs from the current boundary mode, and the menu button ends the
authoring. Orientations stay the identity: the wire format carries a
quaternion, and this script never builds or reads one.

Every hold is counted in Godot frames, not packets: tools/gate_replay.gd sends
its frame number to --frame-port once per frame, and each hold lasts until that
number has advanced by the hold's length. Packets keep flowing at --hz
meanwhile. On a software rasterizer Godot runs at a few frames a second, and a
hold counted in packets would put a whole stroke inside one frame.
"""
import argparse
import json
import os
import socket
import struct
import sys
import time

TRACKING_PORT = 9945
CONTROL_PORT = 9946
FRAME_PORT = 9950
HAND_JOINT_COUNT = 26
FLAGS = 0x0004 | 0x0008  # left and right controller active
BUTTON_MENU = 0x0010
BUTTON_RIGHT_THUMBSTICK = 0x0040
BUTTON_RIGHT_TRIGGER = 0x0100
IDENTITY = (0.0, 0.0, 0.0, 1.0)
HEAD = (0.0, 1.6, 0.0)
LEFT = (-0.3, 1.0, -0.3)
FMT = '<qI' + 'f' * (7 * 3) + 'I' + 'f' * (4 + 2 + 2 + 1 + 4 + 3 + 3 + HAND_JOINT_COUNT * 4 * 2)
assert struct.calcsize(FMT) == 1008, struct.calcsize(FMT)

# ClientConnect (common/protocol/include/oxrsys/protocol/Protocol.h): the
# control-channel handshake OXRSys's StreamingServer requires before it wires
# up the TrackingReceiver to InputManager (StreamingServer::HandleClientConnect
# -> state_ = Connected). Without this, tracking packets on TRACKING_PORT are
# received but never surfaced as controller poses, so gate_replay.gd's calib
# phase spins until timeout even though packets are flowing.
#   MessageType type (u8) = ClientConnect (0x02)
#   u8 versionMajor=1, u8 versionMinor=0, u8 reserved=0
#   u32 preferredCodec, u32 maxBitrateMbps, u32 refreshRateHz
#   char deviceName[64]
CLIENT_CONNECT_FMT = '<BBBBIII64s'
assert struct.calcsize(CLIENT_CONNECT_FMT) == 80, struct.calcsize(CLIENT_CONNECT_FMT)
MESSAGE_TYPE_CLIENT_CONNECT = 0x02


def client_connect_packet():
    device_name = b'gate_replay\x00'
    return struct.pack(CLIENT_CONNECT_FMT,
                        MESSAGE_TYPE_CLIENT_CONNECT, 1, 0, 0,
                        0, 0, 90,
                        device_name.ljust(64, b'\x00'))


def packet(right, trigger=0.0, buttons=0):
    if trigger > 0.05:
        buttons |= BUTTON_RIGHT_TRIGGER
    vals = [time.monotonic_ns(), FLAGS]
    vals += list(HEAD) + list(IDENTITY)
    vals += list(LEFT) + list(IDENTITY)
    vals += list(right) + list(IDENTITY)
    vals += [buttons, 0.0, trigger, 0.0, 0.0]  # buttons, triggers, grips
    vals += [0.0, 0.0, 0.0, 0.0]  # thumbsticks
    vals += [0.0] + [0.0] * 4  # ipd, eye fov: runtime defaults
    vals += [0.0] * 6  # head velocities
    vals += [0.0] * (HAND_JOINT_COUNT * 4 * 2)
    return struct.pack(FMT, *vals)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('plan')
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--hz', type=float, default=90.0)
    ap.add_argument('--wait', type=float, default=600.0, help='seconds to wait for the plan')
    ap.add_argument('--frame-port', type=int, default=FRAME_PORT, help='UDP port gate_replay.gd sends its frame number to')
    ap.add_argument('--frame-timeout', type=float, default=60.0, help='seconds one hold may wait for Godot frames')
    a = ap.parse_args()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dt = 1.0 / a.hz
    sent = [0]

    def send_client_connect():
        sock.sendto(client_connect_packet(), (a.host, CONTROL_PORT))

    frames = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    frames.bind(('127.0.0.1', a.frame_port))
    frames.setblocking(False)
    frame = [-1]

    def poll_frames():
        while True:
            try:
                data, _ = frames.recvfrom(64)
            except BlockingIOError:
                return
            try:
                frame[0] = max(frame[0], int(data))
            except ValueError:
                pass

    def send_packet(right, trigger, buttons):
        sock.sendto(packet(right, trigger, buttons), (a.host, TRACKING_PORT))
        sent[0] += 1
        time.sleep(dt)
        poll_frames()

    def send(right, n, trigger=0.0, buttons=0):
        """Hold this state for n Godot frames (at least one packet)."""
        poll_frames()
        target = frame[0] + n
        t_hold = time.monotonic()
        send_packet(right, trigger, buttons)
        while frame[0] < target:
            if time.monotonic() - t_hold > a.frame_timeout:
                raise SystemExit('replay: Godot frame %d not reached in %.0f s: FAIL' % (target, a.frame_timeout))
            send_packet(right, trigger, buttons)

    calib = (0.0, 1.2, -0.3)
    t0 = time.monotonic()
    connect_interval = 1.0
    last_connect = 0.0
    send_client_connect()
    while not os.path.exists(a.plan):
        if time.monotonic() - t0 > a.wait:
            print('replay: no plan after %.0f s: FAIL' % a.wait)
            return 1
        now = time.monotonic()
        if now - last_connect >= connect_interval:
            send_client_connect()
            last_connect = now
        for _ in range(9):
            send_packet(calib, 0.0, 0)
            if os.path.exists(a.plan):
                break
    plan = json.load(open(a.plan))
    calib = tuple(plan['calib'])
    boundary = False
    for s in plan['strokes']:
        pts = [tuple(p) for p in s['points']]
        send(pts[0], 4)
        if bool(s['boundary']) != boundary:
            send(pts[0], 3, buttons=BUTTON_RIGHT_THUMBSTICK)
            send(pts[0], 3)
            boundary = not boundary
        send(pts[0], 3, trigger=0.5)
        for p in pts[1:]:
            send(p, 2, trigger=0.5)
        send(pts[-1], 4)
        print('replay: %s (%d points, boundary %s)' % (s['name'], len(pts), s['boundary']), flush=True)
    send(calib, 3, buttons=BUTTON_MENU)
    # Keep the controllers tracked while the pipeline meshes, until Godot stops
    # sending frames (it has quit) or --wait runs out.
    t_end = last_seen = time.monotonic()
    last = frame[0]
    while time.monotonic() - t_end < a.wait and time.monotonic() - last_seen < 10.0:
        send_packet(calib, 0.0, 0)
        if frame[0] != last:
            last, last_seen = frame[0], time.monotonic()
    print('replay: done, %d packets' % sent[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
