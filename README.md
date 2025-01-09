# zinc - A NETCONF Client in Zig
> A NETCONF client running over TCP (and SSH...)

## Usage

```bash
zig build run -- [options]
```

### Command Line Options

```
-h, --help                 Display help and exit
--netconf10                Use NETCONF 1.0 (default: 1.1)
-u, --user <username>      Username (default: admin)
-p, --password <password>  Password (default: admin)
--proto [tcp | ssh]        Protocol (default: tcp)
--host <host-or-ip>        Host to connect to (default: localhost)
--port <port-number>       Port to connect to (default: 2022)
--groups <groups>          Groups, comma separated
--sup_gids <sup-groups>    Supplementary groups, comma separated
```

## Example Usage

Connect to a local NETCONF server using default settings:
```bash
zig build run
```

Connect to a specific host with custom credentials:
```bash
zig build run -- --host 192.168.1.100 --port 830 -u operator -p secret
```

Use NETCONF 1.0 with specific groups:
```bash
zig build run -- --netconf10 --groups "netconf,admin" --sup_gids "1000,1001"
```

## TCP Transport Details

When using TCP transport, the client sends a custom header in the following format:
```
[<username>;<IP>;<proto>;<uid>;<gid>;<xtragids>;<homedir>;<group list>;]
```

This header is automatically generated using the system's user information and the provided command line arguments.
