"""Entry point for Pip's bundled runtime. Preserve hook stdin/stdout exactly."""
import json
import platform
import signal
import sys

VERSION = "0.7.2"


def main():
    if sys.argv[1:] == ["--version"]:
        print(json.dumps({"version": VERSION, "bundled": bool(getattr(sys, "frozen", False)),
                          "architecture": platform.machine()}))
        return 0
    if len(sys.argv) < 2:
        print("Use hook, telemetry, demo, chat, or connections.", file=sys.stderr)
        return 2
    if sys.argv[1] == "chat":
        import chat_bridge
        return chat_bridge.main(sys.argv[2:])
    if sys.argv[1] == "connections":
        import connections
        return connections.main(sys.argv[2:])
    import bridge

    def terminated(*_):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, terminated)
    return bridge.main()


if __name__ == "__main__":
    sys.exit(main())
