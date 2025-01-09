# zinc - A NETCONF Client in Zig
> A NETCONF client running over TCP (and SSH...)

## Usage

```bash
zig build run -- [options] [file]
```

### Command Line Options

```
-h, --help                 Display help and exit
--netconf10                Use NETCONF 1.0 (default: 1.1)
--hello                    Only send a NETCONF Hello message
-u, --user <username>      Username (default: admin)
-p, --password <password>  Password (default: admin)
--proto [tcp | ssh]        Protocol (default: tcp)
--host <host-or-ip>        Host to connect to (default: localhost)
--port <port-number>       Port to connect to (default: 2022)
--groups <groups>          Groups, comma separated
--sup-gids <sup-gids>      Supplementary groups, comma separated
```

If no file is specified, the client reads NETCONF commands from stdin.

## Example Usage

Build and connect to a local NETCONF server and send NETCONF messages,
either from a file or from stdin.
```bash
zig build run -- nc-message.xml
```

or if you have already built the project (via stdin this time):

```bash
cat nc-message.xml | ./zig-out/bin/zinc
```

Pipe commands from another program, this time using a custom port:
```bash
echo "<get-config><source><running/></source></get-config>" | zig build run -- --port 2222
```

**Note:** A NETCONF Hello message exchange is automatically made before
sending any NETCONF commands given in the file or via stdin.

To only send a NETCONF Hello message, use the `--hello` flag.

Connect to a specific host with custom credentials:
```bash
zig build run -- --host 192.168.1.100 --port 830 -u operator -p secret
```

Use NETCONF 1.0 with specific groups:
```bash
zig build run -- --netconf10 --groups "netconf,admin" --sup-gids "1000,1001"
```

## TCP Transport Details

When using TCP transport, the client sends a custom (Tail-f) header in the following format:
```
[<username>;<IP>;<proto>;<uid>;<gid>;<xtragids>;<homedir>;<group list>;]
```

This header is automatically generated using the system's user information and the provided command line arguments.
